import SwiftUI

/// A band shown as colour AND word.
struct BandCapsule: View {
    let band: Band
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(band.color).frame(width: 8, height: 8)
            Text(band.word).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(band.color.opacity(0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(band.color.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(band.word)
    }
}

/// Where a value sits between the poor end and the excellent end of its scale.
struct ScaleBar: View {
    let metric: Metric
    let value: Double

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let x = metric.scalePosition(for: value) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Band.poor.color, Band.fair.color, Band.good.color, Band.excellent.color].map { $0.opacity(0.55) },
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Circle()
                        .fill(.background)
                        .overlay(Circle().strokeBorder(.primary, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(x - 6, 0), geo.size.width - 12))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack {
                Text("Poor"); Spacer(); Text("Excellent")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// The ⓘ button and its popover: meaning, what good looks like, how sure, and this camera's or photo's evidence.
struct InfoButton: View {
    let metric: Metric
    /// "In this camera" or "In this photo", with its text; nil leaves the block out.
    var context: (title: String, text: String)?
    @State private var shown = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        } else {
            button
        }
    }

    private var button: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(metric.shortMeaning)
        .accessibilityLabel("About \(metric.displayName)")
        .popover(isPresented: $shown, arrowEdge: .bottom) { MetricDefinition(metric: metric, context: context) }
    }
}

/// The ⓘ popover: four blocks separated by dividers, and Open the Glossary.
struct MetricDefinition: View {
    let metric: Metric
    var context: (title: String, text: String)?
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metric.displayName).font(.headline)
            block("Meaning", metric.definition)
            Divider()
            block("What good looks like", metric.goodLooksLike)
            Divider()
            block("How sure", metric.howSure)
            if let context {
                Divider()
                block(context.title, context.text)
            }
            HStack {
                Spacer()
                Button("Open the Glossary") {
                    model?.glossaryMetric = metric
                    openWindow(id: "glossary")
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A number with its qualifier, drawn one way everywhere so the qualifier cannot be dropped:
/// "At least 8.6 stops", "— · 1 edge", "3,769 LW/PH · 27 edges".
struct MeasuredValue: View {
    let text: String
    var dimmed = false
    var font: Font = .body

    var body: some View {
        Text(text).font(font).monospacedDigit().foregroundStyle(dimmed ? .secondary : .primary)
    }

    enum Qualifier: Hashable, Sendable {
        case none
        /// A lower bound: "At least ".
        case atLeast
        /// Too few edges to count: the value is replaced by "—".
        case notCounted
    }

    /// The text builder, pure so the tests can pin it.
    nonisolated static func text(_ metric: Metric, _ value: Double?, qualifier: Qualifier = .none, edges: Int? = nil) -> String {
        let edgeText = edges.map { " · " + Fmt.count($0, "edge") } ?? ""
        switch qualifier {
        case .notCounted: return "—" + edgeText
        case .atLeast: return value.map { "At least " + metric.format($0) + edgeText } ?? "Not measured"
        case .none: return value.map { metric.format($0) + edgeText } ?? "Not measured"
        }
    }

    /// One photo's row value with its qualifier from the analyzer's gates.
    nonisolated static func photoText(_ m: Metric, _ p: PhotoRecord) -> (text: String, counted: Bool) {
        let v = m.value(of: p)
        switch m {
        case .sharpnessLWPH, .sharpnessCPP:
            guard v != nil else { return ("Not measured", false) }
            return p.hasSharpnessFigure ? (text(m, v, edges: p.edgesMeasured), true) : (text(m, v, qualifier: .notCounted, edges: p.edgesMeasured ?? 0), false)
        case .overshoot:
            guard v != nil else { return ("Not measured", false) }
            return p.hasSharpnessFigure ? (text(m, v), true) : (text(m, v, qualifier: .notCounted, edges: p.edgesMeasured ?? 0), false)
        case .dynamicRange:
            return (text(m, v, qualifier: p.drSNR4LowerBound == true ? .atLeast : .none), v != nil)
        case .snr:
            guard let v else { return ("Not measured", false) }
            return p.snrIsClean ? (text(m, v), true) : (m.format(v) + " · not counted", false)
        default:
            return (text(m, v), v != nil)
        }
    }
}

/// "Solid · 206 photos" with its symbol: the evidence word always beside its count.
struct EvidenceCapsule: View {
    let grade: EvidenceGrade
    let counted: Int

    var body: some View {
        Label("\(grade.word) · \(Fmt.count(counted, "photo"))", systemImage: grade.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
            .help(grade.definition)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(grade.word) evidence, \(Fmt.count(counted, "photo"))")
    }
}

/// "At the camera", with its symbol.
struct EffortLabel: View {
    let effort: Effort
    var body: some View {
        Label(effort.word, systemImage: effort.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .help(effort.definition)
    }
}

/// What to do, grouped under up to three effort headings, in the order at the camera, set up once, in the editor.
struct ActionGroups: View {
    let actions: [Action]
    /// "What to do", or "Try this" on a Thin card.
    var title = "What to do"

    var body: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(Effort.allCases, id: \.self) { effort in
                    let group = actions.filter { $0.effort == effort }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            EffortLabel(effort: effort)
                            ForEach(group, id: \.self) { a in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").accessibilityHidden(true)
                                    Text(a.text).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                                .padding(.leading, 4)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// "Why Am I Seeing This?": opens the rule's five-sentence popover.
struct WhyButton: View {
    let why: WhyShown
    @State private var shown = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Label("Why Am I Seeing This?", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
        } else {
            Button { shown.toggle() } label: {
                Label("Why Am I Seeing This?", systemImage: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("The rule behind this card, what it counted and how sure it is")
            .popover(isPresented: $shown, arrowEdge: .bottom) { WhyPopover(why: why) }
        }
    }
}

struct WhyPopover: View {
    let why: WhyShown
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                block("The rule", why.rule)
                block("What was counted", why.counted)
                block("How sure", why.howSure)
                block("What it cannot tell", why.cannotTell)
                block("Check it yourself", why.checkYourself)
            }
            .padding(16)
        }
        .frame(width: 360)
        .frame(maxHeight: 480)
    }

    @ViewBuilder private func block(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Large, readable statement used for empty states inside a column.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ChartCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A vertical ScrollView, except in PNG snapshots where the content is laid out at its full height.
struct MaybeScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder let content: Content
    var body: some View {
        if isSnapshot { content } else { ScrollView { content } }
    }
}

/// A titled card: GroupBox in the app; a plain rounded container in PNG snapshots, where GroupBox content does not draw.
struct Card<Label: View, Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label
    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 8) { label; content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            GroupBox { content } label: { label }
        }
    }
}

/// A DisclosureGroup in the app; expanded, as plain views, in PNG snapshots.
struct Disclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var expanded = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "chevron.down").font(.headline)
                content.padding(.leading, 20)
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) { content }.padding(.top, 8)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}
