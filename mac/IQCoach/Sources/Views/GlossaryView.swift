import SwiftUI

/// The Glossary window: every metric (Metrics tab) and how the app measures and decides (Method tab).
struct GlossaryView: View {
    @State private var selection: Metric.ID? = Metric.sharpnessLWPH.id
    @State private var tab = "Metrics"
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 16) {
                Text("Glossary").font(.largeTitle.weight(.bold))
                SnapshotGrid(columns: [
                    ("Metric", { $0.displayName }), ("Unit", { $0.unit.isEmpty ? "—" : $0.unit }),
                    ("What good looks like", { $0.goodLooksLike }),
                ], rows: Metric.allCases)
                ForEach(Metric.allCases.prefix(4)) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.displayName).font(.headline)
                        Text(m.definition).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("How sure: " + m.howSure).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Text("Method").font(.title.weight(.bold))
                MethodBody()
            }
            .padding(24)
        } else {
            TabView(selection: $tab) {
                metrics.tabItem { Text("Metrics") }.tag("Metrics")
                ScrollView { MethodBody().padding(20).frame(maxWidth: 720, alignment: .leading) }
                    .tabItem { Text("Method") }.tag("Method")
            }
            .padding(.top, 8)
            .onAppear { if let m = model?.glossaryMetric { selection = m.id; tab = "Metrics" } }
            .onChange(of: model?.glossaryMetric) { _, m in if let m { selection = m.id; tab = "Metrics" } }
        }
    }

    private var metrics: some View {
        VStack(spacing: 0) {
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
                        Text("How sure").font(.subheadline.weight(.semibold)).padding(.top, 4)
                        Text(m.howSure).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .frame(height: 220)
        }
    }

    private func scaleText(_ m: Metric) -> String {
        "\(m.scale.lowerBound.formatted()) to \(m.scale.upperBound.formatted())"
    }
}

/// The Method tab: headed paragraphs.
struct MethodBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Method.sections) { s in
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    ForEach(s.paragraphs, id: \.self) { p in
                        Text(p).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
