import SwiftUI

struct InsightCard: View {
    let insight: Insight

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
                Divider()
                Text("Based on \(Fmt.count(insight.basedOn, "photo"))")
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
        .accessibilityElement(children: .combine)
    }
}
