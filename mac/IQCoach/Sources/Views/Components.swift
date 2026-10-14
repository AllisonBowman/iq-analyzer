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

/// The ⓘ button and its popover: definition and what good looks like.
struct InfoButton: View {
    let metric: Metric
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
        .help("What is \(metric.displayName)?")
        .accessibilityLabel("About \(metric.displayName)")
        .popover(isPresented: $shown, arrowEdge: .bottom) { MetricDefinition(metric: metric) }
    }
}

struct MetricDefinition: View {
    let metric: Metric
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.displayName).font(.headline)
            Text(metric.definition).font(.callout).fixedSize(horizontal: false, vertical: true)
            Divider()
            Label(metric.goodLooksLike, systemImage: "checkmark.seal").font(.callout)
        }
        .padding(16)
        .frame(width: 360)
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
