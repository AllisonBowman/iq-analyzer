import SwiftUI
import Charts

private let isoTicks: [Double] = [50, 100, 200, 400, 800, 1600, 3200]

/// SNR against ISO: a dot per photo, a line through each ISO band's median, the clean mark (Metric.snrCleanDB).
struct SNRvsISOChart: View {
    let camera: CameraGroup

    private var points: [PhotoRecord] { camera.photos.filter { $0.snrIsClean && $0.iso != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noise against ISO").font(.headline)
            Chart {
                ForEach(points) { p in
                    PointMark(x: .value("ISO", p.iso ?? 0), y: .value("SNR (dB)", p.snrMidgreyDB ?? 0))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .symbolSize(24)
                }
                ForEach(camera.summary.snrByBand) { b in
                    LineMark(x: .value("ISO", b.band.representativeISO), y: .value("Median SNR (dB)", b.median))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("ISO", b.band.representativeISO), y: .value("Median SNR (dB)", b.median))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(60)
                }
                RuleMark(y: .value("Clean", Metric.snrCleanDB))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.green)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("\(Fmt.db(Metric.snrCleanDB)): clean").font(.caption).foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: 25...6400, type: .log)
            .chartXAxis {
                AxisMarks(values: isoTicks) { v in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.int(d)) } }
                }
            }
            .chartXAxisLabel("ISO (log scale)")
            .chartYAxisLabel("Signal to noise (dB), higher is cleaner")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 240)
            .accessibilityLabel("Chart of noise against ISO for \(camera.model)")
            .accessibilityValue(camera.summary.snrByBand.map { "\($0.band.label): \(Fmt.db($0.median))" }.joined(separator: ". "))
            ChartCaption(text: "Each dot is one photo with a clean noise reading and the blue line joins the median of each ISO band; where the line sinks below the dashed \(Fmt.db(Metric.snrCleanDB)) mark, grain becomes visible.")
        }
    }
}

struct LensSharpnessChart: View {
    let camera: CameraGroup

    private var rows: [(name: String, value: Double, n: Int)] {
        let names = CameraRules.lensNames(camera.lenses)
        return camera.lenses.compactMap { l in
            guard let v = l.p80Sharpness else { return nil }
            let human = names[l.name] ?? l.name
            let label = camera.lenses.count == 1 && l.name == PhotoRecord.unknownLens ? l.name : (camera.isPhone ? human.capitalizedFirst : l.name)
            return (label, v, l.sharpnessCount)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sharpness by lens").font(.headline)
            Chart(rows, id: \.name) { r in
                BarMark(x: .value("In-focus sharpness (LW/PH)", r.value), y: .value("Lens", r.name))
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .trailing) {
                        Text("\(Fmt.int(r.value)) (n=\(r.n))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: 0...(max(4000, (rows.map(\.value).max() ?? 0) * 1.3)))
            .chartXAxisLabel("In-focus sharpness, LW/PH (longer is sharper)")
            .frame(height: CGFloat(max(rows.count, 1)) * 44 + 64)
            .accessibilityLabel("Bar chart of sharpness by lens for \(camera.model)")
            .accessibilityValue(rows.map { "\($0.name): \(Fmt.lwph($0.value))" }.joined(separator: ". "))
            ChartCaption(text: "The longest bar is the lens that resolves the finest detail; n is the number of photos with 3 or more usable edges behind each bar. Lenses with none are not drawn.")
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct ClippingChart: View {
    let camera: CameraGroup

    private var rows: [(name: String, share: Double)] {
        [("Highlights blown", camera.summary.clipHighShare), ("Shadows crushed", camera.summary.clipLowShare)]
            .compactMap { n, s in s.map { (n, $0 * 100) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photos with clipping").font(.headline)
            Chart {
                ForEach(rows, id: \.name) { r in
                    BarMark(x: .value("Share of photos (%)", r.share), y: .value("Kind", r.name))
                        .foregroundStyle(r.share > 15 ? Color.orange : Color.accentColor)
                        .annotation(position: .trailing) {
                            Text(Fmt.pct(r.share)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                }
                RuleMark(x: .value("Threshold", 15))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) { Text("15 %").font(.caption).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: 0...max(40, (rows.map(\.share).max() ?? 0) * 1.2))
            .chartXAxisLabel("Share of photos with more than 1 % of the picture clipped (%)")
            .frame(height: 150)
            .accessibilityLabel("Bar chart of clipping share for \(camera.model)")
            .accessibilityValue(rows.map { "\($0.name): \(Fmt.pct($0.share))" }.joined(separator: ". "))
            ChartCaption(text: "Bars past the dashed 15 % line (orange) mean exposure routinely loses highlight or shadow detail.")
        }
    }
}

/// One line per camera: used on the library overview.
struct LibrarySNRChart: View {
    let cameras: [CameraGroup]

    private var series: [(camera: String, band: SNRBandStat)] {
        cameras.filter { $0.photos.count >= CameraRules.minPhotos && $0.summary.snrByBand.filter { $0.count >= 3 }.count >= 2 }
            .prefix(8)
            .flatMap { c in c.summary.snrByBand.filter { $0.count >= 3 }.map { (c.model, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noise against ISO, every camera").font(.headline)
            Chart {
                ForEach(series, id: \.band.id) { s in
                    LineMark(x: .value("ISO", s.band.band.representativeISO), y: .value("Median SNR (dB)", s.band.median),
                             series: .value("Camera", s.camera))
                        .foregroundStyle(by: .value("Camera", s.camera))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("ISO", s.band.band.representativeISO), y: .value("Median SNR (dB)", s.band.median))
                        .foregroundStyle(by: .value("Camera", s.camera))
                        .symbolSize(40)
                }
                RuleMark(y: .value("Clean", Metric.snrCleanDB))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.green)
            }
            .chartXScale(domain: 25...6400, type: .log)
            .chartXAxis {
                AxisMarks(values: isoTicks) { v in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.int(d)) } }
                }
            }
            .chartXAxisLabel("ISO (log scale)")
            .chartYAxisLabel("Median signal to noise (dB)")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 300)
            .accessibilityLabel("Line chart of median noise against ISO, one line per camera")
            ChartCaption(text: "A flat line means the camera hides noise as ISO rises; a falling line means grain takes over. The dashed green line is the \(Fmt.db(Metric.snrCleanDB)) clean mark.")
        }
    }
}
