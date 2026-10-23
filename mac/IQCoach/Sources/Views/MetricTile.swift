import SwiftUI

/// One report-card figure: the number with its qualifier (drawn by `MeasuredValue`, so it cannot be dropped), the band
/// with its word, and a caption saying what the number is a median of and what was left out.
struct MetricTile: View {
    let metric: Metric
    let title: String
    /// Value used for the number, the band and the scale bar.
    let value: Double?
    var qualifier: MeasuredValue.Qualifier = .none
    /// Set when too few photos pass the gate: replaces the number, the band and the scale.
    var notEnough: String?
    /// The number as written when it differs from `value` (sharpness is banded on c/px but shown in LW/PH).
    var shownAs: String?
    /// What the figure rests on, and the caveat that matters.
    let evidence: String
    var banded = true
    /// The ⓘ popover's "In this camera" block.
    var context: String?

    @State private var showDefinition = false

    private var band: Band? { notEnough == nil && banded ? value.flatMap { metric.band(for: $0) } : nil }

    var numberText: String { notEnough ?? shownAs ?? MeasuredValue.text(metric, value, qualifier: qualifier) }

    var spokenSummary: String {
        var parts = ["\(title): \(numberText)"]
        if let band { parts.append(band.word) }
        parts.append(evidence)
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).help(metric.shortMeaning)
                Spacer()
                InfoButton(metric: metric, context: context.map { ("In this camera", $0) })
            }
            MeasuredValue(text: numberText, dimmed: notEnough != nil || value == nil,
                          font: .system(notEnough == nil ? .largeTitle : .title2, design: .rounded).weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let band { BandCapsule(band: band) }
            if band != nil, let value { ScaleBar(metric: metric, value: value) }
            Text(evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
        .accessibilityAction(named: "Show definition") { showDefinition = true }
        .popover(isPresented: $showDefinition) { MetricDefinition(metric: metric, context: context.map { ("In this camera", $0) }) }
    }
}
