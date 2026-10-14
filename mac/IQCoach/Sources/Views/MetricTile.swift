import SwiftUI

struct MetricTile: View {
    let metric: Metric
    let title: String
    /// Value used for the band and scale bar.
    let value: Double?
    var valueText: String?
    var detail: String?
    var prefix: String = ""
    var banded = true

    @State private var showDefinition = false

    private var band: Band? { banded ? value.flatMap { metric.band(for: $0) } : nil }

    private var numberText: String {
        if let valueText { return valueText }
        guard let value else { return "Not measured" }
        return metric.format(value)
    }

    var spokenSummary: String {
        var parts = ["\(title): \(prefix)\(numberText)"]
        if let band { parts.append(band.word) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                InfoButton(metric: metric)
            }
            Text(value == nil && valueText == nil ? numberText : prefix + numberText)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let band { BandCapsule(band: band) }
            if band != nil, let value { ScaleBar(metric: metric, value: value) }
            Text(detail ?? metric.shortMeaning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
        .accessibilityAction(named: "Show definition") { showDefinition = true }
        .popover(isPresented: $showDefinition) { MetricDefinition(metric: metric) }
    }
}
