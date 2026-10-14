import SwiftUI

struct GlossaryView: View {
    @State private var selection: Metric.ID? = Metric.sharpnessLWPH.id
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            if isSnapshot {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Glossary").font(.largeTitle.weight(.bold))
                    SnapshotGrid(columns: [
                        ("Metric", { $0.displayName }), ("Unit", { $0.unit.isEmpty ? "—" : $0.unit }),
                        ("What good looks like", { $0.goodLooksLike }),
                    ], rows: Metric.allCases)
                    ForEach(Metric.allCases.prefix(6)) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.displayName).font(.headline)
                            Text(m.definition).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(24)
            } else {
                Table(Metric.allCases, selection: $selection) {
                    TableColumn("Metric") { m in Text(m.displayName) }.width(min: 150, ideal: 190)
                    TableColumn("Unit") { m in Text(m.unit.isEmpty ? "—" : m.unit) }.width(70)
                    TableColumn("Scale") { m in Text(scaleText(m)) }.width(min: 90, ideal: 120)
                    TableColumn("What it tells you") { m in Text(m.shortMeaning).lineLimit(2) }
                }
                Divider()
                ScrollView {
                    if let m = Metric.allCases.first(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(m.displayName).font(.headline)
                            Text(m.definition).fixedSize(horizontal: false, vertical: true)
                            Label(m.goodLooksLike, systemImage: "checkmark.seal")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
                .frame(height: 170)
            }
        }
    }

    private func scaleText(_ m: Metric) -> String {
        "\(m.scale.lowerBound.formatted()) to \(m.scale.upperBound.formatted())"
    }
}
